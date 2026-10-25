@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// The recorder as the Record button and the menu bar drive it, with the
/// hardware swapped for a hook that writes small stand-in audio files into
/// the staging folder. Everything after that (state, timer, pause, stop,
/// sealing into the session folder, the launch sweep) is the real code.
@MainActor
final class RecordingBench {
    let app: InProcessDriver
    let recorder: SessionRecorder
    let stagingRoot: URL
    let scratchRoot: URL
    let tempRoot: URL
    private(set) var stopped: [SessionRecorder.ActiveRecording] = []
    private(set) var lastRefusal: String?
    var lastSweep: OrphanAudioSweep.Result?

    static let micBytes = Data("mic-audio".utf8)
    static let callBytes = Data("call-audio".utf8)

    init(app: InProcessDriver) throws {
        self.app = app
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-record-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = base.appendingPathComponent("staging", isDirectory: true)
        scratchRoot = base.appendingPathComponent("scratch", isDirectory: true)
        tempRoot = base.appendingPathComponent("tmp", isDirectory: true)
        for dir in [stagingRoot, scratchRoot, tempRoot] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        recorder = SessionRecorder(stagingDirectoryURL: stagingRoot)
        recorder.audioCaptureStartOverride = { mic, call in
            try Self.micBytes.write(to: mic)
            try Self.callBytes.write(to: call)
        }
        recorder.onStopped = { [weak self] in self?.stopped.append($0) }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempRoot.deletingLastPathComponent())
    }

    var store: Store { app.appModel.store! }

    func context(for patient: Patient, session: SessionRecord) -> SessionRecorder.ActiveRecording {
        .init(
            sessionID: session.id, patientID: patient.id, patientName: patient.name,
            patientSlug: patient.slug, sessionFolder: session.folderName)
    }

    /// What the Record Session button does: the new-PHI gate, then the recorder.
    @discardableResult
    func pressRecord(patient: Patient, session: SessionRecord) async -> String? {
        guard app.appModel.authorizeNewPHI() else { return nil }
        lastRefusal = await recorder.start(
            micURL: store.micRecordingURL(for: patient, session: session),
            callURL: store.callRecordingURL(for: patient, session: session),
            context: context(for: patient, session: session),
            protector: app.appModel.currentProtector)
        return lastRefusal
    }

    func sweepAtLaunch() -> OrphanAudioSweep.Result {
        OrphanAudioSweep.sweep(
            store: store, protector: app.appModel.currentProtector,
            stagingRoot: stagingRoot, scratchRoot: scratchRoot, temporaryDirectory: tempRoot)
    }

    func stagedFolder(for session: SessionRecord) -> URL {
        Store.stagingDir(for: session.id, in: stagingRoot)
    }
}

/// A patient and one of their sessions.
struct PatientSession {
    let patient: Patient
    let session: SessionRecord
}

/// The files a session folder holds for one recording.
struct RecordedFiles {
    let mic: URL
    let call: URL

    var micExists: Bool { FileManager.default.fileExists(atPath: mic.path) }
    var callExists: Bool { FileManager.default.fileExists(atPath: call.path) }
}

// MARK: - Given

extension Given {
    func recordingBench() throws -> RecordingBench { try RecordingBench(app: app) }

    /// A patient with one empty session, ready to record.
    func aPatientWithASession(named name: String = "Jane Doe") async throws -> PatientSession {
        let patient = try await patient(named: name)
        return PatientSession(patient: patient, session: try aSession(for: patient))
    }

    /// Another empty session for the same patient.
    func anotherSession(for visit: PatientSession) throws -> PatientSession {
        PatientSession(patient: visit.patient, session: try aSession(for: visit.patient))
    }

    func aSession(for patient: Patient) throws -> SessionRecord {
        try XCTUnwrap(app.appModel.store).createSession(
            for: patient, on: app.clock.now.addingTimeInterval(Double.random(in: 1...1_000_000)))
    }

    /// The Mac's microphone permission is refused.
    func microphoneIsDenied(_ bench: RecordingBench) {
        bench.recorder.audioCaptureStartOverride = { _, _ in throw MicRecorderError.permissionDenied }
    }
}

// MARK: - When

struct ReminderAlert {
    let title: String
    let buttons: [String]
}

extension When {
    func files(of session: SessionRecord, patient: Patient, bench: RecordingBench) -> RecordedFiles {
        RecordedFiles(
            mic: bench.store.micRecordingURL(for: patient, session: session),
            call: bench.store.callRecordingURL(for: patient, session: session))
    }

    /// Plays sound through the Mac for a while: `polls` meter refreshes.
    func hearSound(on bench: RecordingBench, mic: Float, call: Float, polls: Int = 10) {
        for _ in 0..<polls {
            bench.recorder.updateLevels(dt: 1.0 / 15.0, rawMicLevel: mic, rawCallLevel: call)
        }
    }

    /// Records with no call audio, `seconds` of unpaused time, one poll a second.
    func recordWithoutCallAudio(on bench: RecordingBench, seconds: Int) {
        for _ in 0..<seconds {
            bench.recorder.updateLevels(dt: 1, rawMicLevel: 0.5, rawCallLevel: 0)
        }
    }

    /// Force-quit: the recorder is dropped with its files still staged, the
    /// app opens again over the same data folder and runs its launch sweep.
    func forceQuitAndReopen(_ bench: RecordingBench) {
        app.relaunch(tier: app.tier)
        bench.lastSweep = bench.sweepAtLaunch()
    }

    /// What the Record Session button does.
    @discardableResult
    func pressRecord(on bench: RecordingBench, _ visit: PatientSession) async -> String? {
        await bench.pressRecord(patient: visit.patient, session: visit.session)
    }

    /// What the two level bars show right now.
    func readMeters(on bench: RecordingBench) -> (mic: Float, call: Float) {
        (mic: bench.recorder.levels.mic, call: bench.recorder.levels.call)
    }

    /// Records with the reminder set to fire after `seconds` instead of 90 minutes.
    func recordWithReminderAfter(_ seconds: TimeInterval, on bench: RecordingBench, _ visit: PatientSession) async {
        bench.recorder.reminderThreshold = seconds
        await bench.pressRecord(patient: visit.patient, session: visit.session)
    }

    /// Waits for the alert to be raised, then reads what it offers.
    func waitForStillRecordingAlert(on bench: RecordingBench) async throws -> ReminderAlert {
        try await eventually(within: 5, "the Still recording alert is raised") { bench.recorder.longRunningReminder }
        return ReminderAlert(title: RecordingLimit.Alert.title, buttons: [RecordingLimit.Alert.keep, RecordingLimit.Alert.stop])
    }

    /// Keep Recording: the alert closes and the recording goes on.
    func keepRecording(on bench: RecordingBench) { bench.recorder.longRunningReminder = false }

    /// Stop Now.
    func stopNow(on bench: RecordingBench) async { await bench.recorder.stop() }

    func pause(on bench: RecordingBench) { bench.recorder.pause() }
    func resume(on bench: RecordingBench) { bench.recorder.resume() }
    func stop(on bench: RecordingBench) async { await bench.recorder.stop() }

    func files(of visit: PatientSession, bench: RecordingBench) -> RecordedFiles {
        files(of: visit.session, patient: visit.patient, bench: bench)
    }

    /// Deletes the patient's folder from the data folder, as Finder would.
    func deleteFolder(of patient: Patient, bench: RecordingBench) throws {
        try FileManager.default.removeItem(at: bench.store.patientDir(for: patient))
    }

    /// The list under Settings that holds recordings with nowhere to go.
    func openSetAsideRecordings(on bench: RecordingBench) -> SetAsideRecordings {
        SetAsideRecordings(stagingRoot: bench.stagingRoot)
    }

    /// Review in Settings, then recover the first item into `visit`.
    func recoverFirstSetAside(_ list: SetAsideRecordings, into visit: PatientSession, bench: RecordingBench) throws {
        let item = try XCTUnwrap(list.items.first, "nothing was set aside")
        try OrphanAudioSweep.recoverSetAside(
            item.folder, into: visit.patient, session: visit.session, store: bench.store,
            protector: app.appModel.currentProtector, stagingRoot: bench.stagingRoot)
    }

    /// Delete…, then confirm, on the first set-aside recording.
    func deleteFirstSetAside(_ list: SetAsideRecordings) throws -> URL {
        let item = try XCTUnwrap(list.items.first, "nothing was set aside")
        try list.delete(item, audit: nil)
        return item.folder
    }
}

// MARK: - Then

@MainActor extension Then where Subject == RecordingBench {
    func isRecording(_ session: SessionRecord) {
        let recorder = subject.recorder
        expect(recorder.isRecording, "the recorder is not recording")
        expectEqual(recorder.active?.sessionID, session.id, "the session being recorded")
        expect(recorder.startedAt != nil, "no start time, so no running timer")
        expect(!recorder.isPaused, "the recording starts paused")
        expect(recorder.elapsed(at: Date().addingTimeInterval(5)) >= 4.9, "the timer does not run")
    }

    func isNotRecording() {
        expect(!subject.recorder.isRecording, "a recording is running")
        expect(subject.recorder.active == nil, "a session is marked as recording")
    }

    func metersMove() {
        let levels = subject.recorder.levels
        expect(levels.mic > 0, "the microphone bar did not move (\(levels.mic))")
        expect(levels.call > 0, "the call audio bar did not move (\(levels.call))")
    }

    func metersAreSilent() {
        let levels = subject.recorder.levels
        expect(levels.mic == 0 && levels.call == 0, "the bars moved with no sound (\(levels.mic), \(levels.call))")
    }

    func metersAreLouder(than before: (mic: Float, call: Float)) {
        let levels = subject.recorder.levels
        expect(levels.mic > before.mic, "the microphone bar did not rise with louder sound")
        expect(levels.call > before.call, "the call audio bar did not rise with louder sound")
    }

    func warnsOnlyMicrophoneIsRecorded() {
        let recorder = subject.recorder
        expect(recorder.callAudioSilent && !recorder.isPaused, "no warning that only the microphone is recorded")
    }

    func doesNotWarnAboutCallAudio() {
        expect(!subject.recorder.callAudioSilent, "warned about call audio too early")
    }

    func refusedBecauseAnotherIsRecording(_ refusal: String?) {
        expect(refusal != nil, "a second recording was allowed to start")
        expect(refusal?.lowercased().contains(Copy.stillRecording) == true,
               "the refusal does not say a recording is still running: \(refusal ?? "nil")")
    }

    func stillRecording(_ session: SessionRecord) {
        expectEqual(subject.recorder.active?.sessionID, session.id, "the session still being recorded")
    }

    func pointsToSystemSettings(_ message: String?) {
        expect(message?.contains(Copy.systemSettings) == true,
               "the message does not say how to allow it in System Settings: \(message ?? "nil")")
    }

    func savedBothFiles(_ files: RecordedFiles) {
        expect(files.micExists, "the microphone file was not saved with the session")
        expect(files.callExists, "the call audio file was not saved with the session")
        expectEqual((try? Data(contentsOf: files.mic)) ?? Data(), RecordingBench.micBytes, "the saved microphone audio")
        expectEqual((try? Data(contentsOf: files.call)) ?? Data(), RecordingBench.callBytes, "the saved call audio")
    }

    func leftNothingStaged(for session: SessionRecord) {
        expect(!FileManager.default.fileExists(atPath: subject.stagedFolder(for: session).path),
               "audio is still staged after Stop")
    }

    func startedTranscriptionOnItsOwn(for session: SessionRecord) {
        expectEqual(subject.stopped.map(\.sessionID), [session.id], "sessions reported as finished")
        expect(subject.app.settings.autoTranscribeAfterRecording, "automatic transcription is off by default")
    }
}

@MainActor extension Then where Subject == ReminderAlert {
    func asksWhetherYouForgot() {
        expectEqual(subject.title, "Still recording", "the alert's title")
        expectEqual(subject.buttons, ["Keep Recording", "Stop Now"], "the alert's buttons")
    }
}

@MainActor extension Then where Subject == RecordedFiles {
    func hold(_ bytes: Data, onMic: Bool = true) {
        let url = onMic ? subject.mic : subject.call
        expectEqual((try? Data(contentsOf: url)) ?? Data(), bytes, "the recovered audio at \(url.lastPathComponent)")
    }

    func areMissing() {
        expect(!subject.micExists && !subject.callExists, "audio was added to the session")
    }
}

@MainActor extension Then where Subject == SetAsideRecordings {
    func listsItems(_ count: Int) {
        subject.refresh()
        expectEqual(subject.items.count, count, "set-aside recordings listed")
    }

    func warningDoesNotNamePatient(of visit: PatientSession) {
        let names = [visit.patient.name, visit.patient.slug] + visit.patient.name.split(separator: " ").map(String.init)
        let text = SetAsideRecordings.warningText(count: max(1, subject.items.count))
        for name in names {
            expect(!text.localizedCaseInsensitiveContains(name), "the warning names \(name): \(text)")
        }
        expect(text.contains("set aside"), "the warning does not say a recording is set aside: \(text)")
    }
}

@MainActor extension Then where Subject == RecordingBench {
    func showsTurnOnFileVaultAlert() {
        expectEqual(subject.app.appModel.fileVaultNotice?.title, Copy.turnOnFileVault, "the FileVault alert")
    }
}

@MainActor extension Then where Subject == RecordingBench {
    func isRecording(_ visit: PatientSession) { isRecording(visit.session) }
    func stillRecording(_ visit: PatientSession) { stillRecording(visit.session) }
    func leftNothingStaged(for visit: PatientSession) { leftNothingStaged(for: visit.session) }
    func startedTranscriptionOnItsOwn(for visit: PatientSession) { startedTranscriptionOnItsOwn(for: visit.session) }

    /// The timer stands still while paused, however long the Mac waits.
    func timerHolds() {
        let soon = subject.recorder.elapsed(at: Date().addingTimeInterval(10))
        let later = subject.recorder.elapsed(at: Date().addingTimeInterval(600))
        expect(subject.recorder.isPaused, "the recording is not paused")
        expect(abs(soon - later) < 0.001, "the timer kept running while paused")
    }

    /// The reminder is due at 90 minutes and not a second before.
    func remindsAtNinetyMinutes() {
        expectEqual(RecordingLimit.reminderThreshold, 90 * 60, "the reminder threshold in seconds")
        expect(!RecordingLimit.shouldRemind(elapsed: 90 * 60 - 1), "reminded early")
        expect(RecordingLimit.shouldRemind(elapsed: 90 * 60), "no reminder at 90 minutes")
    }

    /// The launch sweep put one interrupted recording back into its session.
    func recoveredOneInterruptedSession() {
        expectEqual(subject.lastSweep?.stagedSessionsRecovered, 1, "interrupted sessions recovered")
    }

    func setAsideOneRecording() {
        expectEqual(subject.lastSweep?.quarantinedUnknownDirs, 1, "recordings set aside")
    }
}

@MainActor extension Then where Subject == URL {
    func isGone() {
        expect(!FileManager.default.fileExists(atPath: subject.path), "the audio is still on disk")
    }
}

@MainActor extension Then where Subject == String? {
    func isNoRefusal() {
        expect(subject == nil, "the recording was refused: \(subject ?? "")")
    }
}
