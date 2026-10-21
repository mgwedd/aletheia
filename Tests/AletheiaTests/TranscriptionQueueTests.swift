import XCTest
@testable import Aletheia

/// One transcription at a time, the rest in the order they were asked for.
final class TranscriptionQueueTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testFirstSubmissionStartsAndLaterOnesWait() {
        var queue = TranscriptionQueue()
        XCTAssertEqual(queue.submit(a), .startNow)
        XCTAssertEqual(queue.submit(b), .queued)
        XCTAssertEqual(queue.submit(c), .queued)
        XCTAssertEqual(queue.running, a)
        XCTAssertEqual(queue.waiting, [b, c])
        XCTAssertFalse(queue.isWaiting(a))
        XCTAssertTrue(queue.isWaiting(b))
    }

    func testResubmittingRunningOrWaitingSessionChangesNothing() {
        var queue = TranscriptionQueue()
        _ = queue.submit(a)
        _ = queue.submit(b)
        let before = queue
        XCTAssertEqual(queue.submit(a), .alreadyKnown)
        XCTAssertEqual(queue.submit(b), .alreadyKnown)
        XCTAssertEqual(queue, before)
    }

    func testFinishingStartsTheNextInOrderThenGoesIdle() {
        var queue = TranscriptionQueue()
        _ = queue.submit(a)
        _ = queue.submit(b)
        _ = queue.submit(c)
        XCTAssertEqual(queue.finishRunning(), b)
        XCTAssertEqual(queue.running, b)
        XCTAssertEqual(queue.waiting, [c])
        XCTAssertEqual(queue.finishRunning(), c)
        XCTAssertNil(queue.finishRunning())
        XCTAssertNil(queue.running)
        // Idle again: the next submission starts straight away.
        XCTAssertEqual(queue.submit(a), .startNow)
    }

    func testWithdrawRemovesOnlyAWaitingSession() {
        var queue = TranscriptionQueue()
        _ = queue.submit(a)
        _ = queue.submit(b)
        _ = queue.submit(c)
        XCTAssertFalse(queue.withdraw(a), "the running one is cancelled, not withdrawn")
        XCTAssertTrue(queue.withdraw(b))
        XCTAssertFalse(queue.withdraw(b))
        XCTAssertEqual(queue.running, a)
        XCTAssertEqual(queue.finishRunning(), c)
    }

    func testFinishedSessionCanBeTranscribedAgain() {
        var queue = TranscriptionQueue()
        _ = queue.submit(a)
        _ = queue.submit(b)
        _ = queue.finishRunning()
        // `a` is done, so re-transcribing it queues behind `b` rather than being ignored.
        XCTAssertEqual(queue.submit(a), .queued)
    }
}

/// Every reason a session's Record or Transcribe button is unavailable has words.
final class SessionActionPolicyTests: XCTestCase {
    private func transcribe(
        thisRecording: Bool = false, elsewhere: Bool = false, transcribing: Bool = false,
        queued: Bool = false, hasRecording: Bool = true
    ) -> String? {
        SessionActionPolicy.transcribeBlocker(
            isRecordingThisSession: thisRecording, isRecordingElsewhere: elsewhere,
            isTranscribing: transcribing, isQueued: queued, hasRecording: hasRecording
        )
    }

    func testTranscribeIsAllowedWhenIdleWithAudio() {
        XCTAssertNil(transcribe())
    }

    func testTranscribeBlockersEachExplainThemselves() {
        XCTAssertEqual(transcribe(thisRecording: true), "Stop the recording first")
        XCTAssertEqual(transcribe(elsewhere: true), "Another session is recording. Stop it first")
        XCTAssertEqual(transcribe(transcribing: true), "This session is being transcribed")
        XCTAssertEqual(transcribe(queued: true), "Waiting for another transcription to finish")
        XCTAssertEqual(transcribe(hasRecording: false), "Record this session first — there is no audio to transcribe")
    }

    func testRecordingThisSessionWinsOverMissingAudio() {
        // Mid-recording the files may not be listed yet; the live reason is the useful one.
        XCTAssertEqual(transcribe(thisRecording: true, hasRecording: false), "Stop the recording first")
    }

    func testRecordBlockers() {
        XCTAssertNil(SessionActionPolicy.recordBlocker(isTranscribing: false, isQueued: false, isStarting: false))
        XCTAssertEqual(
            SessionActionPolicy.recordBlocker(isTranscribing: true, isQueued: false, isStarting: false),
            "Finish transcribing first"
        )
        XCTAssertNotNil(SessionActionPolicy.recordBlocker(isTranscribing: false, isQueued: true, isStarting: false))
        XCTAssertEqual(
            SessionActionPolicy.recordBlocker(isTranscribing: false, isQueued: false, isStarting: true),
            "A recording is starting"
        )
    }
}

/// A session offers only the actions that can act on it: no Record over an
/// existing transcript or recording, no Transcribe without audio, no Export
/// of nothing.
final class SessionActionOfferTests: XCTestCase {
    private func record(
        transcript: Bool = false, recording: Bool = false, transcribing: Bool = false, queued: Bool = false
    ) -> Bool {
        SessionActionPolicy.offersRecord(
            hasTranscript: transcript, hasRecording: recording, isTranscribing: transcribing, isQueued: queued
        )
    }

    func testRecordIsOfferedOnlyOnAnEmptySession() {
        XCTAssertTrue(record())
        XCTAssertFalse(record(transcript: true), "a transcribed session is not recorded over")
        XCTAssertFalse(record(recording: true), "audio waiting to be transcribed is not recorded over")
        XCTAssertFalse(record(transcribing: true))
        XCTAssertFalse(record(queued: true))
    }

    func testTranscribeNeedsAudioOrWorkUnderWay() {
        XCTAssertFalse(SessionActionPolicy.offersTranscribe(hasRecording: false, isTranscribing: false, isQueued: false))
        XCTAssertTrue(SessionActionPolicy.offersTranscribe(hasRecording: true, isTranscribing: false, isQueued: false))
        XCTAssertTrue(SessionActionPolicy.offersTranscribe(hasRecording: false, isTranscribing: true, isQueued: false))
        XCTAssertTrue(SessionActionPolicy.offersTranscribe(hasRecording: false, isTranscribing: false, isQueued: true))
    }

    func testExportNeedsATranscriptOrSummary() {
        XCTAssertFalse(SessionActionPolicy.offersExport(hasTranscript: false, hasSummary: false))
        XCTAssertTrue(SessionActionPolicy.offersExport(hasTranscript: true, hasSummary: false))
        XCTAssertTrue(SessionActionPolicy.offersExport(hasTranscript: false, hasSummary: true))
    }

    func testTranscribedSessionWithoutKeptAudioOffersNeitherRecordNorTranscribe() {
        XCTAssertFalse(record(transcript: true))
        XCTAssertFalse(SessionActionPolicy.offersTranscribe(hasRecording: false, isTranscribing: false, isQueued: false))
    }

    func testSessionBarGatesEachActionOnThePolicy() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/SessionDetailView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("} else if offersRecord {"))
        XCTAssertTrue(source.contains("if offersTranscribe {"))
        XCTAssertTrue(source.contains("SessionActionPolicy.offersExport("))
        XCTAssertFalse(source.contains(".disabled(transcriptText.isEmpty && summaryText.isEmpty)"))
    }
}

/// Automatic transcription is on until the user turns it off.
final class AutoTranscribeDefaultTests: XCTestCase {
    private let suite = "AutoTranscribeDefaultTests"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOnWhenNeverChosen() {
        XCTAssertTrue(AppSettings.resolvedAutoTranscribe(in: defaults))
    }

    func testExplicitChoiceIsRespected() {
        defaults.set(false, forKey: "autoTranscribeAfterRecording")
        XCTAssertFalse(AppSettings.resolvedAutoTranscribe(in: defaults))
        defaults.set(true, forKey: "autoTranscribeAfterRecording")
        XCTAssertTrue(AppSettings.resolvedAutoTranscribe(in: defaults))
    }
}
