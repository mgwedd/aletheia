@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// What the speech-to-text model on this Mac is like.
enum SpeechModel {
    /// Never downloaded.
    case notDownloaded
    /// Downloaded, but the file is the wrong size.
    case damaged
    /// Ready; the test says what it hears and when.
    case ready
}

/// The step the speech model says it is on.
enum ModelStep {
    case preparingAudio
    case microphone
    case callAudio

    fileprivate var stage: TranscriptionStage {
        switch self {
        case .preparingAudio: .preparing
        case .microphone: .transcribingMic
        case .callAudio: .transcribingCall
        }
    }
}

/// A session with its recordings on disk.
struct RecordedSession {
    let patient: Patient
    let session: SessionRecord
}

/// What the progress band and the menu bar show for one session.
struct TranscriptionBand {
    let isRunning: Bool
    let isWaiting: Bool
    /// What the band is called.
    let title: String
    let stage: String?
    let percent: Int?
    let menuBarLine: String?
}

/// What is stored for a session.
struct SessionOnDisk {
    let hasTranscript: Bool
    let hasRecording: Bool
    let transcript: String?
}

/// How a transcription ended, and what the person was told.
struct TranscriptionResult {
    let outcome: TranscriptionOutcome
    let notificationTitles: [String]
    let onDisk: SessionOnDisk

    var failureMessage: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }
    var blankNotice: String? {
        if case .blank(let notice) = outcome { return notice }
        return nil
    }
}

/// What a person reads in the finished transcript.
struct TranscriptReading {
    let text: String
    var lines: [String] { text.split(separator: "\n").map(String.init) }
}

private struct SpeechFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A transcriber the test steers: it reports what it is told, then finishes or
/// fails when told. With `autoFinish` it simply returns that text.
private final class SteeredTranscriber: Transcribing, @unchecked Sendable {
    enum Step {
        case report(TranscriptionProgress)
        case finish(String)
        case fail(String)
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var consumed = 0
    private var delivered = 0
    var isReady: Bool { true }

    func push(_ step: Step) { lock.lock(); steps.append(step); lock.unlock() }
    /// Steps whose effect (a progress report) has been handed to the app.
    var deliveredCount: Int { lock.lock(); defer { lock.unlock() }; return delivered }
    private func didDeliver() { lock.lock(); delivered += 1; lock.unlock() }

    private func next() -> Step? {
        lock.lock(); defer { lock.unlock() }
        guard !steps.isEmpty else { return nil }
        consumed += 1
        return steps.removeFirst()
    }

    func transcribeSession(
        micURL: URL?, callURL: URL?, onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            switch next() {
            case .report(let progress)?:
                onProgress(progress)
                didDeliver()
            case .finish(let text)?: return text
            case .fail(let message)?: throw SpeechFailure(message: message)
            case nil: try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
}

private final class RecordingNotifier: AppNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [AppNotificationContent] = []
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return posted.map(\.title) }
    func requestAuthorization() async {}
    func post(_ content: AppNotificationContent) async {
        lock.lock(); posted.append(content); lock.unlock()
    }
}

/// The transcription side of the app, over the real coordinator, store and
/// settings, with the speech model swapped for one the test controls.
@MainActor
final class TranscriptionDesk {
    private let app: InProcessDriver
    private let model: SpeechModel
    private let steered: SteeredTranscriber
    private let notifier: RecordingNotifier
    private let quitting: ShutdownCoordinator
    private var coordinator: TranscriptionCoordinator
    private let modelFolder: URL
    private static let rawAudio = Data("RAW-AUDIO-MARKER".utf8)

    fileprivate init(app: InProcessDriver, model: SpeechModel) throws {
        let steered = SteeredTranscriber()
        let notifier = RecordingNotifier()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = app.root
        let quitting = ShutdownCoordinator(ledger: { InterruptedWorkLedger(dataRoot: root) })
        let coordinator = Self.makeCoordinator(app: app, model: model, steered: steered, notifier: notifier, folder: folder)
        quitting.register(coordinator)
        self.app = app
        self.model = model
        self.steered = steered
        self.notifier = notifier
        self.modelFolder = folder
        self.quitting = quitting
        self.coordinator = coordinator
    }

    deinit { try? FileManager.default.removeItem(at: modelFolder) }

    private static func makeCoordinator(
        app: InProcessDriver, model: SpeechModel, steered: SteeredTranscriber,
        notifier: RecordingNotifier, folder: URL
    ) -> TranscriptionCoordinator {
        let transcriber: Transcribing
        switch model {
        case .ready:
            transcriber = steered
        case .notDownloaded:
            transcriber = WhisperTranscriber(modelPath: folder.appendingPathComponent("absent.bin"))
        case .damaged:
            let file = folder.appendingPathComponent("truncated.bin")
            try? Data("short".utf8).write(to: file)
            transcriber = WhisperTranscriber(modelPath: file, expectedBytes: 1_000_000)
        }
        let integrations = Integrations(settings: app.settings, transcriber: transcriber, notifier: notifier)
        return TranscriptionCoordinator(
            appModel: app.appModel, integrations: integrations, settings: app.settings)
    }

    // MARK: Scene

    /// A session of `patient` with its mic and call recordings on disk.
    func recordSession(of patient: Patient, daysAgo: Int = 0) throws -> RecordedSession {
        let store = try XCTUnwrap(app.appModel.store)
        let date = app.clock.now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let created = try store.createSession(for: patient, on: date)
        try Self.rawAudio.write(to: store.micRecordingURL(for: patient, session: created))
        try Self.rawAudio.write(to: store.callRecordingURL(for: patient, session: created))
        app.appModel.refreshPatients()
        return RecordedSession(patient: patient, session: try current(created, of: patient))
    }

    /// The session already has a transcript from an earlier run.
    func alreadyTranscribed(_ recorded: RecordedSession, as text: String) throws {
        let store = try XCTUnwrap(app.appModel.store)
        try store.saveTranscript(text, for: recorded.patient, session: recorded.session)
    }

    func turnOnEncryption() throws {
        try app.encryption.enable(passphrase: "test-passphrase-1", iterations: 100_000)
    }

    func keepRawAudioAfterTranscription() { app.settings.keepAudioRecordings = true }

    /// The speech model will say these lines when it is let finish.
    func modelWillHear(_ lines: [(speaker: String, at: TimeInterval, text: String)]) {
        let spoken = lines.map { TranscribedLine(source: $0.speaker, startTime: $0.at, endTime: $0.at + 3, text: $0.text) }
        steered.push(.finish(TranscriptFormatter.format(spoken)))
    }

    func modelWillHearNothing() { steered.push(.finish("")) }

    // MARK: Actions

    func pressTranscribe(_ recorded: RecordedSession) throws {
        coordinator.start(patient: recorded.patient, session: try current(recorded.session, of: recorded.patient))
    }

    func pressCancel(_ recorded: RecordedSession) { coordinator.cancel(sessionID: recorded.session.id) }

    /// The model reports being at `fraction` of `stage`.
    func modelReports(_ fraction: Double, in step: ModelStep = .microphone) async throws {
        let before = steered.deliveredCount
        steered.push(.report(TranscriptionProgress(stage: step.stage, fraction: fraction)))
        try await eventually("the progress report") { self.steered.deliveredCount > before }
        // The app applies a report in a main-actor task queued while it was delivered;
        // this one queues behind it, so the report has been applied once it runs.
        await Task { @MainActor in }.value
    }

    func modelFails(saying message: String) { steered.push(.fail(message)) }

    /// Waits for the transcription to end and reports how.
    func waitForResult(of recorded: RecordedSession) async throws -> TranscriptionResult {
        try await eventually("the transcription to end") { self.coordinator.outcomes[recorded.session.id] != nil }
        let outcome = try XCTUnwrap(coordinator.takeOutcome(for: recorded.session.id))
        return TranscriptionResult(
            outcome: outcome, notificationTitles: notifier.titles, onDisk: try onDisk(recorded))
    }

    func transcribe(_ recorded: RecordedSession) async throws -> TranscriptionResult {
        try pressTranscribe(recorded)
        return try await waitForResult(of: recorded)
    }

    func band(of recorded: RecordedSession) -> TranscriptionBand {
        let job = coordinator.job(for: recorded.session.id)
        return TranscriptionBand(
            isRunning: job != nil,
            isWaiting: coordinator.isWaiting(recorded.session.id),
            title: TranscriptionProgressView.title,
            stage: job?.progress.stage.title,
            percent: job.map { Int($0.progress.fraction * 100) },
            menuBarLine: coordinator.statusLine)
    }

    /// Quits mid-transcription and opens the app again, which picks the work up.
    func quitAndReopen() async throws {
        await quitting.shutDown()
        let root = app.root
        app.relaunch(tier: app.tier)
        app.appModel.refreshPatients()
        coordinator = Self.makeCoordinator(app: app, model: model, steered: steered, notifier: notifier, folder: modelFolder)
        let store = try XCTUnwrap(app.appModel.store)
        let ledger = InterruptedWorkLedger(dataRoot: root)
        let left = InterruptedWorkResumer.resume(
            ledger.load(), patients: app.appModel.patients,
            sessions: { try? store.listSessions(for: $0) },
            transcribe: { [coordinator] in coordinator.start(patient: $0.patient, session: $0.session) },
            summarize: { _ in })
        ledger.save(left)
    }

    // MARK: Reading

    func readTranscript(of recorded: RecordedSession) throws -> TranscriptReading {
        let store = try XCTUnwrap(app.appModel.store)
        let stored = try XCTUnwrap(try store.readTranscript(for: recorded.patient, session: recorded.session), "no transcript is stored")
        let first = Prompts.clientFirstName(recorded.patient.name)
        return TranscriptReading(text: TranscriptStyler.forReader(stored, callAudioName: first))
    }

    func onDisk(_ recorded: RecordedSession) throws -> SessionOnDisk {
        let store = try XCTUnwrap(app.appModel.store)
        let now = try current(recorded.session, of: recorded.patient)
        return SessionOnDisk(
            hasTranscript: now.hasTranscript, hasRecording: now.hasRecording,
            transcript: try store.readTranscript(for: recorded.patient, session: recorded.session))
    }

    /// Whether the raw audio sits on disk in the clear.
    var rawAudioIsReadableOnDisk: Bool { app.probe.containsPlaintext("RAW-AUDIO-MARKER") }
    func isReadableOnDisk(_ text: String) -> Bool { app.probe.containsPlaintext(text) }

    // MARK: Helpers

    private func current(_ session: SessionRecord, of patient: Patient) throws -> SessionRecord {
        let store = try XCTUnwrap(app.appModel.store)
        let listed = try store.listSessions(for: patient)
        return try XCTUnwrap(listed.first { $0.id == session.id }, "session \(session.id) \(session.folderName) is gone; listed: \(listed.map { "\($0.id) \($0.folderName)" })")
    }
}

// MARK: - Given

extension Given {
    /// The transcription side of the app, with the speech model as described.
    func transcriptionDesk(speechModel: SpeechModel) throws -> TranscriptionDesk {
        try TranscriptionDesk(app: app, model: speechModel)
    }
}

// MARK: - Then

extension Then where Subject == TranscriptionResult {
    func finishedNormally() {
        expectEqual(subject.outcome, .completed, "how the transcription ended")
    }

    func failedSaying(_ message: String) {
        expectEqual(subject.failureMessage, message, "the reason shown")
    }

    func failedWith(reasonContaining text: String) {
        expect(subject.failureMessage?.contains(text) == true,
               "expected the reason to mention \"\(text)\", found \(String(describing: subject.failureMessage))")
    }

    func wasCancelled() { expectEqual(subject.outcome, .cancelled, "how the transcription ended") }

    func saysNoSpeechWasDetected() {
        expect(subject.blankNotice?.contains(Copy.noSpeechDetected) == true,
               "expected a no-speech notice, found \(String(describing: subject.blankNotice))")
    }

    func warnsKeptRecordingIsNotEncrypted() {
        expect(subject.blankNotice?.contains(Copy.encryptionIsOffNotice) == true,
               "expected a warning that the kept recording is not encrypted, found \(String(describing: subject.blankNotice))")
    }

    func sentNotification(titled title: String) {
        expect(subject.notificationTitles.contains(title),
               "expected a \"\(title)\" notification, found \(subject.notificationTitles)")
    }

    func sentNoNotification(titled title: String) {
        expect(!subject.notificationTitles.contains(title), "did not expect a \"\(title)\" notification")
    }

    func leftNoTranscript() { expect(!subject.onDisk.hasTranscript, "a transcript was written") }
    func keptTheRecording() { expect(subject.onDisk.hasRecording, "the recording was deleted") }
    func deletedTheRecording() { expect(!subject.onDisk.hasRecording, "the recording is still there") }
    func savedATranscript() { expect(subject.onDisk.hasTranscript, "no transcript was saved") }

    func keptTheExistingTranscript(_ text: String) {
        expectEqual(subject.onDisk.transcript, text, "the stored transcript")
    }
}

extension Then where Subject == TranscriptionBand {
    func isWaitingForItsTurn() {
        expect(subject.isWaiting && !subject.isRunning, "expected the session to be waiting, not running")
    }
    func isTranscribing() { expect(subject.isRunning, "expected the session to be transcribing") }
    func isNotTranscribing() { expect(!subject.isRunning && !subject.isWaiting, "expected no transcription for the session") }
    func isTitled(_ title: String) { expectEqual(subject.title, title, "the band's title") }
    func showsStage(_ stage: String) { expectEqual(subject.stage, stage, "the stage") }
    func showsPercent(_ percent: Int) { expectEqual(subject.percent, percent, "the percentage") }
    func menuBarShows(_ line: String) { expectEqual(subject.menuBarLine, line, "the menu bar line") }
}

extension Then where Subject == TranscriptionDesk {
    @MainActor
    func rawAudioIsNotReadableOnDisk() {
        expect(!subject.rawAudioIsReadableOnDisk, "the kept recording is stored in the clear")
    }
    @MainActor
    func isNotReadableOnDisk(_ text: String) {
        expect(!subject.isReadableOnDisk(text), "\"\(text)\" is stored in the clear")
    }
}

extension Then where Subject == TranscriptReading {
    func linesAreTimeStamped() {
        let pattern = #"^\[\d{2}:\d{2}\] "#
        let bad = subject.lines.filter { $0.range(of: pattern, options: .regularExpression) == nil }
        expect(!subject.lines.isEmpty && bad.isEmpty, "lines without an [MM:SS] time stamp: \(bad)")
    }
    func hasLine(_ stamp: String, from speaker: String, saying text: String) {
        let want = "[\(stamp)] \(speaker): \(text)"
        expect(subject.lines.contains(want), "expected the line \"\(want)\", found \(subject.lines)")
    }
    /// Every line the client spoke is led by their first name, whole on one line.
    func clientTurnsStartWith(_ name: String, saying text: String) {
        let turns = subject.lines.filter { $0.contains(text) }
        expect(!turns.isEmpty, "the client's turn is missing: \(subject.lines)")
        let bad = turns.filter { $0.range(of: #"^\[\d{2}:\d{2}\] "# + NSRegularExpression.escapedPattern(for: name) + ": ", options: .regularExpression) == nil }
        expect(bad.isEmpty, "turns that do not start with \"\(name):\": \(bad)")
    }
    func neverNamesSpeaker(_ speaker: String) {
        expect(!subject.text.contains("\(speaker):"), "the transcript still names \"\(speaker)\"")
    }
}

extension Then where Subject == SessionOnDisk {
    func hasRecording() { expect(subject.hasRecording, "the session has no recording") }
}
