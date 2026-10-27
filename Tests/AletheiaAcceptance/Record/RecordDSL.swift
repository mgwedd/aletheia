@testable import Aletheia
import AVFoundation
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
        do {
            try await eventually(within: 5, "the Still recording alert is raised") { bench.recorder.longRunningReminder }
        } catch let timeout as EventuallyTimeout {
            // Say what the recorder was doing, so a failure shows why no alert came.
            throw EventuallyTimeout(
                what: "\(timeout.what) (recorder state: \(bench.recorder.state))", seconds: timeout.seconds)
        }
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

// MARK: - Import Audio…

/// What the Import Audio… button does: the FileVault and consent gates, then
/// the real import of the file that was picked, over a scratch folder of its own.
@MainActor
final class ImportBench {
    enum Step: Equatable {
        /// The Turn on FileVault alert is up and nothing else happens.
        case refused
        /// An alert says a license key is needed and nothing else happens.
        case refusedForLicense
        /// The consent sheet opens first; the picker waits for it.
        case asksForConsent
        case opensFilePicker
    }

    let app: InProcessDriver
    let folder: URL
    private let originalScratch: URL
    private(set) var failure: String?

    init(app: InProcessDriver) throws {
        self.app = app
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        originalScratch = PrivateStaging.root
        PrivateStaging.root = folder.appendingPathComponent("scratch", isDirectory: true)
    }

    func cleanUp() {
        PrivateStaging.root = originalScratch
        try? FileManager.default.removeItem(at: folder)
    }

    var store: Store { app.appModel.store! }

    /// Whether the session screen offers Import Audio… beside Record Session.
    func offersImport(for visit: PatientSession) -> Bool {
        let hasRecording = [store.micRecordingURL(for: visit.patient, session: visit.session),
                            store.callRecordingURL(for: visit.patient, session: visit.session)]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        return SessionActionPolicy.offersRecord(
            hasTranscript: false, hasRecording: hasRecording, isTranscribing: false, isQueued: false)
    }

    func press(for visit: PatientSession) -> Step {
        switch app.appModel.beginAudioImport(patient: visit.patient, session: visit.session) {
        case .blocked: return .refused
        case .refused(let message):
            failure = message
            return .refusedForLicense
        case .needsConsent: return .asksForConsent
        case .ready: return .opensFilePicker
        }
    }

    /// The same call the view makes with the picked file.
    func importFile(_ file: URL, into visit: PatientSession) {
        do {
            try store.importRecording(from: file, for: visit.patient, session: visit.session)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func write(_ data: Data, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Two seconds of a 440 Hz tone, as a WAV from a phone might be.
    func writeTone(named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let rate = 44_100.0
        let frames = AVAudioFrameCount(2 * rate)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / Float(rate))
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buffer)
        return url
    }
}

extension Given {
    func importBench() throws -> ImportBench { try ImportBench(app: app) }

    /// The patient has already said yes to being recorded.
    func recordingConsent(of visit: PatientSession) {
        app.appModel.updatePatient(id: visit.patient.id) { $0.recordingConsentAttestedAt = Date() }
    }

    /// An audio file the user keeps somewhere on the Mac.
    func anAudioFile(_ bench: ImportBench) throws -> URL { try bench.writeTone(named: "visit.wav") }

    /// A file that carries an audio extension but no sound.
    func aFileThatIsNotAudio(_ bench: ImportBench) throws -> URL {
        try bench.write(Data("these words are not audio".utf8), named: "notes.m4a")
    }

    /// The session already holds a recording made in the app.
    func aRecording(_ bytes: Data, in visit: PatientSession, _ bench: ImportBench) throws {
        try bytes.write(to: bench.store.micRecordingURL(for: visit.patient, session: visit.session))
    }

    /// No license key has been added on this Mac.
    func noLicenseKey() {
        let suite = "aletheia-acceptance-license-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        UserDefaults().removePersistentDomain(forName: suite)
        let license = LicenseState(settings: settings)
        app.appModel.newRecordingRefusal = { license.newWorkRefusal }
    }

    /// The session's progress note is written and signed.
    func aSignedNote(in visit: PatientSession, _ bench: ImportBench) throws {
        try bench.store.saveGeneratedNote("S: calm", for: visit.patient, session: visit.session, format: .soap)
        _ = try bench.store.signNote(for: visit.patient, session: visit.session, format: .soap, signer: "mw:501")
    }
}

extension When {
    /// Click Import Audio….
    func pressImportAudio(on bench: ImportBench, _ visit: PatientSession) -> ImportBench.Step {
        bench.press(for: visit)
    }

    /// Tick the consent box and continue; the picker opens once the patient is attested.
    func confirmRecordingConsent(on bench: ImportBench, _ visit: PatientSession) -> ImportBench.Step {
        var capture = ConsentCapture()
        capture.confirmed = true
        _ = try? app.appModel.recordConsent(capture, patient: visit.patient, session: visit.session)
        return bench.press(for: visit)
    }

    /// Pick `file` in the open panel.
    func pick(_ file: URL, on bench: ImportBench, into visit: PatientSession) {
        bench.importFile(file, into: visit)
    }

    func recordedFiles(of visit: PatientSession, _ bench: ImportBench) -> RecordedFiles {
        RecordedFiles(
            mic: bench.store.micRecordingURL(for: visit.patient, session: visit.session),
            call: bench.store.callRecordingURL(for: visit.patient, session: visit.session))
    }
}

@MainActor extension Then where Subject == ImportBench.Step {
    func opensTheFilePicker() { expectEqual(subject, .opensFilePicker, "what Import Audio… did") }
    func asksForConsentFirst() { expectEqual(subject, .asksForConsent, "what Import Audio… did") }
    func isRefused() { expectEqual(subject, .refused, "what Import Audio… did") }
    func isRefusedForLicense() { expectEqual(subject, .refusedForLicense, "what Import Audio… did") }
}

@MainActor extension Then where Subject == ImportBench {
    func hasNoFailure() {
        expect(subject.failure == nil, "the import failed: \(subject.failure ?? "")")
    }

    func becameTheRecording(of visit: PatientSession) throws {
        let mic = subject.store.micRecordingURL(for: visit.patient, session: visit.session)
        let readable = try subject.store.readableRecording(at: mic)
        defer { if readable.isTemporary { try? FileManager.default.removeItem(at: readable.url) } }
        let samples = try AudioResampler.loadWhisperSamples(from: readable.url)
        expect(!samples.isEmpty, "the session's recording holds no sound")
        expect(abs(Double(samples.count) - 32_000) < 3_200, "the recording is not about two seconds long (\(samples.count) samples)")
    }

    func leftTheOriginalAlone(_ file: URL, _ original: Data) {
        expectEqual((try? Data(contentsOf: file)) ?? Data(), original, "the picked file")
    }

    func startsTranscriptionOnItsOwn() {
        expect(subject.app.settings.autoTranscribeAfterRecording, "automatic transcription is off by default")
    }

    func savedNothing(for visit: PatientSession) {
        let files = RecordedFiles(
            mic: subject.store.micRecordingURL(for: visit.patient, session: visit.session),
            call: subject.store.callRecordingURL(for: visit.patient, session: visit.session))
        expect(!files.micExists && !files.callExists, "audio was added to the session")
    }

    func refusedAsNotAudio() {
        expect(subject.failure?.contains(Copy.couldntReadAsAudio) == true,
               "the alert does not say the file couldn't be read as audio: \(subject.failure ?? "nil")")
    }

    func saysALicenseKeyIsNeeded() {
        expect(subject.failure?.contains(Copy.needsLicenseKey) == true,
               "the alert does not say a license key is needed: \(subject.failure ?? "nil")")
    }

    func refusedBecauseTheNoteIsSigned() {
        expect(subject.failure?.contains(Copy.noteIsSigned) == true,
               "the alert does not say the note is signed: \(subject.failure ?? "nil")")
    }

    func refusedToReplaceTheRecording() {
        expect(subject.failure?.contains(Copy.alreadyHasRecording) == true,
               "the alert does not say the session already has a recording: \(subject.failure ?? "nil")")
    }

    func keptTheRecording(of visit: PatientSession, _ bytes: Data) {
        let mic = subject.store.micRecordingURL(for: visit.patient, session: visit.session)
        expectEqual((try? Data(contentsOf: mic)) ?? Data(), bytes, "the recording the session already had")
    }

    func offersImport(for visit: PatientSession) {
        expect(subject.offersImport(for: visit), "Import Audio… is not offered")
    }

    func offersNoImport(for visit: PatientSession) {
        expect(!subject.offersImport(for: visit), "Import Audio… is offered for a session that has a recording")
    }

    func showsTurnOnFileVaultAlert() {
        expectEqual(subject.app.appModel.fileVaultNotice?.title, Copy.turnOnFileVault, "the FileVault alert")
    }
}
