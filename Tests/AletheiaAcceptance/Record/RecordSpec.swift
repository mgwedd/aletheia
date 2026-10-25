@testable import Aletheia
import XCTest

final class RecordSpec: AcceptanceCase {
    private var bench: RecordingBench!

    override func setUp() async throws {
        try await super.setUp()
        bench = try given.recordingBench()
    }

    override func tearDown() async throws {
        bench?.cleanUp()
        bench = nil
        try await super.tearDown()
    }

    private func readySession() async throws -> (Patient, SessionRecord) {
        let patient = try await given.patient(named: "Jane Doe")
        return (patient, try given.aSession(for: patient))
    }

    func test_RECORD_01() async throws {
        // Partial: the state the red dot, timer and buttons are drawn from.
        // The pixels themselves need a UI driver.
        let (patient, session) = try await readySession()

        let refusal = await bench.pressRecord(patient: patient, session: session)

        XCTAssertNil(refusal)
        then(bench).isRecording(session)
    }

    func test_RECORD_02() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)
        let quiet = (mic: bench.recorder.levels.mic, call: bench.recorder.levels.call)

        when.hearSound(on: bench, mic: 0.3, call: 0.3)
        then(bench).metersMove()
        let soft = (mic: bench.recorder.levels.mic, call: bench.recorder.levels.call)
        XCTAssertEqual(quiet.mic, 0)

        when.hearSound(on: bench, mic: 0.9, call: 0.9, polls: 30)
        then(bench).metersAreLouder(than: soft)
    }

    func test_RECORD_03() async throws {
        // Partial: a second recording is refused and the first is untouched.
        // The "Recording another session" label is drawn by the session view.
        let (patient, first) = try await readySession()
        let second = try given.aSession(for: patient)
        await bench.pressRecord(patient: patient, session: first)

        let refusal = await bench.pressRecord(patient: patient, session: second)

        then(bench).refusedBecauseAnotherIsRecording(refusal)
        then(bench).stillRecording(first)
    }

    func test_RECORD_04() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)

        bench.recorder.pause()
        let soon = bench.recorder.elapsed(at: Date().addingTimeInterval(10))
        let later = bench.recorder.elapsed(at: Date().addingTimeInterval(600))

        XCTAssertTrue(bench.recorder.isPaused, check.headline)
        XCTAssertEqual(soon, later, accuracy: 0.001, "\(check.headline)\nthe timer kept running while paused")

        bench.recorder.resume()

        XCTAssertFalse(bench.recorder.isPaused, check.headline)
        then(bench).isRecording(session)
    }

    func test_RECORD_05() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)

        when.recordWithoutCallAudio(on: bench, seconds: 60)
        then(bench).doesNotWarnAboutCallAudio()

        when.recordWithoutCallAudio(on: bench, seconds: 30)
        then(bench).warnsOnlyMicrophoneIsRecorded()
    }

    func test_RECORD_06() async throws {
        // Partial: the permission prompt itself is the system's; the refusal
        // is injected at the capture start and the app's response is checked.
        let (patient, session) = try await readySession()
        given.microphoneIsDenied(bench)

        let message = await bench.pressRecord(patient: patient, session: session)

        then(bench).isNotRecording()
        then(bench).pointsToSystemSettings(message)
    }

    func test_RECORD_07() async throws {
        let (patient, session) = try await readySession()
        given.fileVaultIsOff()

        await bench.pressRecord(patient: patient, session: session)

        then(bench).isNotRecording()
        then(bench).showsTurnOnFileVaultAlert()
    }

    func test_RECORD_08() async throws {
        // Partial: the 90-minute rule. The alert and its buttons are drawn by
        // the root view; the timer that raises it runs in real time.
        XCTAssertEqual(RecordingLimit.reminderThreshold, 90 * 60, check.headline)
        XCTAssertFalse(RecordingLimit.shouldRemind(elapsed: 90 * 60 - 1), check.headline)
        XCTAssertTrue(RecordingLimit.shouldRemind(elapsed: 90 * 60), check.headline)
        try pending("seam: the reminder timer sleeps 90 real minutes (no injectable clock), and the alert needs a UI driver")
    }

    func test_RECORD_09() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)

        await bench.recorder.stop()

        then(bench).isNotRecording()
        then(bench).savedBothFiles(when.files(of: session, patient: patient, bench: bench))
        then(bench).leftNothingStaged(for: session)
        then(bench).startedTranscriptionOnItsOwn(for: session)
    }

    func test_RECORD_10() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)
        let files = when.files(of: session, patient: patient, bench: bench)
        then(files).areMissing()

        when.forceQuitAndReopen()
        let result = bench.sweepAtLaunch()

        XCTAssertEqual(result.stagedSessionsRecovered, 1, check.headline)
        let recovered = when.files(of: session, patient: patient, bench: bench)
        then(recovered).hold(RecordingBench.micBytes)
        then(recovered).hold(RecordingBench.callBytes, onMic: false)
    }

    func test_RECORD_11() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)
        try FileManager.default.removeItem(at: bench.store.patientDir(for: patient))

        when.forceQuitAndReopen()
        let result = bench.sweepAtLaunch()
        let setAside = SetAsideRecordings(stagingRoot: bench.stagingRoot)

        XCTAssertEqual(result.quarantinedUnknownDirs, 1, check.headline)
        then(setAside).listsItems(1)
        then(setAside).warningNames(nobody: [patient.name, patient.slug, "Jane", "Doe"])
    }

    func test_RECORD_12() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)
        try FileManager.default.removeItem(at: bench.store.patientDir(for: patient))
        when.forceQuitAndReopen()
        _ = bench.sweepAtLaunch()
        let setAside = SetAsideRecordings(stagingRoot: bench.stagingRoot)
        let item = try XCTUnwrap(setAside.items.first, "nothing was set aside")

        let other = try await given.patient(named: "John Roe")
        let target = try given.aSession(for: other)
        try OrphanAudioSweep.recoverSetAside(
            item.folder, into: other, session: target, store: bench.store,
            protector: app.appModel.currentProtector, stagingRoot: bench.stagingRoot)

        let files = when.files(of: target, patient: other, bench: bench)
        then(files).hold(RecordingBench.micBytes)
        then(files).hold(RecordingBench.callBytes, onMic: false)
        then(setAside).listsItems(0)
    }

    func test_RECORD_13() async throws {
        let (patient, session) = try await readySession()
        await bench.pressRecord(patient: patient, session: session)
        try FileManager.default.removeItem(at: bench.store.patientDir(for: patient))
        when.forceQuitAndReopen()
        _ = bench.sweepAtLaunch()
        let setAside = SetAsideRecordings(stagingRoot: bench.stagingRoot)
        let item = try XCTUnwrap(setAside.items.first, "nothing was set aside")

        try setAside.delete(item, audit: nil)

        then(setAside).listsItems(0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.folder.path), "\(check.headline)\nthe audio is still on disk")
    }
}
