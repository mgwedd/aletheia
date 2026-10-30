@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// The summary row on a patient's page: its status text and the one control beside it.
struct SummaryRowState {
    let text: String?
    let button: String?
}

/// The alert titles the app has shown.
struct AlertReadout {
    let titles: [String]
}

/// The Transcript tab's build status for one session.
struct DigestStatus {
    let title: String?
    let hasSteps: Bool
    let failure: String?
    let offersRetry: Bool
}

// MARK: - The desk

/// A patient's background summaries over the real scheduler and builder, with
/// the model swapped for one the test steers. The scheduler is attached the way
/// the app attaches it at launch.
@MainActor
final class SummariesDesk {
    let desk: AssistantDesk
    let patient: Patient
    private var bench: RecordingBench?

    init(desk: AssistantDesk, patient: Patient) {
        self.desk = desk
        self.patient = patient
    }

    private var scheduler: DigestScheduler { desk.integrations.digestScheduler }
    private var builder: DigestBuilder { desk.integrations.digests }

    // MARK: Scene

    /// Starts the background scheduler as the app does at launch.
    func startScheduler() {
        let scheduler = scheduler
        desk.app.stopOnShutDown { await scheduler.shutDown() }
        scheduler.attach(
            context: { [weak self] in
                guard let self, let store = try? self.desk.store else { return nil }
                return DigestScheduler.Context(
                    store: store, patients: self.desk.app.appModel.patients,
                    service: self.desk.integrations.makeAssistantService())
            },
            activity: { [weak self] in
                DigestActivity(recording: self?.bench?.recorder.isBusy ?? false)
            })
    }

    /// A session of the patient whose transcript is far too long to read whole.
    @discardableResult
    func addLongSession(daysAgo: Int = 0) throws -> StoredSession {
        try desk.session(of: patient, transcript: AssistantDesk.longTranscript(), daysAgo: daysAgo)
    }

    /// The patient's page is opened.
    func openPatientPage() {
        scheduler.patientOpened(patient)
    }

    // MARK: Actions

    /// The row's one control (Pause, Resume or Prepare now).
    func pressRowButton() {
        guard let action = scheduler.status(for: patient.id)?.action else { return }
        scheduler.perform(action, patientID: patient.id)
    }

    func retry(_ stored: StoredSession) {
        scheduler.retry(patient: patient, session: stored.session)
    }

    /// Saves a new transcript for the session, as the transcript editor does.
    func editTranscript(of stored: StoredSession, to text: String) throws {
        try desk.store.saveTranscript(text, for: patient, session: stored.session)
        scheduler.transcriptSaved(patient: patient, session: stored.session)
    }

    /// Records the session and stops it, as the Record button and Stop do.
    func recordAndStop(on stored: StoredSession) async throws {
        let bench = try RecordingBench(app: desk.app)
        self.bench = bench
        let scheduler = scheduler
        let appWiring = bench.recorder.onStopped
        bench.recorder.onStopped = { appWiring?($0); scheduler.recordingStopped() }
        if let refusal = await bench.pressRecord(patient: patient, session: stored.session) {
            XCTFail("the recording did not start: \(refusal)")
            return
        }
        await bench.recorder.stop()
    }

    // MARK: Reading

    var row: SummaryRowState {
        let status = scheduler.status(for: patient.id)
        return SummaryRowState(text: status?.text, button: status?.action?.title)
    }

/// The Transcript tab's build status for the session.
    func transcriptStatus(of stored: StoredSession) -> DigestStatus {
        let id = stored.session.id
        let progress = builder.progress[id]
        return DigestStatus(
            title: progress.map { AIProgressFormat.statusLine(DigestBuilder.statusProgress($0), now: Date()) },
            hasSteps: progress?.steps != nil,
            failure: builder.failures[id],
            offersRetry: builder.failures[id] != nil)
    }

    /// What the app has told the user, by alert title.
    var alerts: AlertReadout { AlertReadout(titles: desk.notifier.titles) }

    /// Whether a summary is stored for the session's transcript as it is now.
    func hasSummary(for stored: StoredSession, transcript: String) -> Bool {
        guard let store = try? desk.store else { return false }
        return store.anyCurrentDigest(for: patient, session: stored.session, transcript: transcript) != nil
    }

    // MARK: Waiting

    func waitForRow(_ text: String) async throws {
        try await desk.waitFor("the summary row to read \"\(text)\"", within: 60) {
            self.row.text?.hasPrefix(text) == true
        }
    }

    /// The first summary is being written: the row says so and the model has been asked.
    /// (A pause is only held on a request that has already begun.)
    func waitForFirstSummaryToBeInProgress() async throws {
        try await waitForRow("Summaries: 0 of 3 ready · preparing")
        try await desk.waitFor("the model to be asked for the first summary", within: 30) {
            self.desk.model.startedCount > 0
        }
    }

    func waitForRowToRead(exactly text: String) async throws {
        try await desk.waitFor("the summary row to read exactly \"\(text)\"", within: 10) {
            self.row.text == text
        }
    }

    func waitForSummary(_ stored: StoredSession) async throws {
        let transcript = try desk.store.readTranscript(for: patient, session: stored.session) ?? ""
        try await waitForSummary(stored, transcript: transcript)
    }

    func waitForSummary(_ stored: StoredSession, transcript: String) async throws {
        try await desk.waitFor("a summary of the session", within: 120) {
            self.hasSummary(for: stored, transcript: transcript)
        }
    }

    func waitForTranscriptSteps(_ stored: StoredSession) async throws {
        try await desk.waitFor("the build to show a step bar", within: 60) {
            self.transcriptStatus(of: stored).hasSteps
        }
    }

    func waitForFailure(_ stored: StoredSession) async throws {
        try await desk.waitFor("the build to fail", within: 60) {
            self.transcriptStatus(of: stored).failure != nil
        }
    }
}

// MARK: - Model steering

extension SteeredModel {
    /// Lets every held step of an answer that reads in parts run to its end.
    func letReadingFinish() {
        for _ in 0..<6 { release() }
    }

    /// The first request fails as it would if the model file were removed mid-build.
    func removesTheModelAfterTheFirstSection() {
        writes("The first part.", once: true)
        answer(nil, with: .fails(LocalLLMEngineError.modelNotDownloaded))
    }
}

// MARK: - Expectations

extension Then where Subject == SummaryRowState {
    func reads(_ text: String) {
        expectEqual(subject.text, text, "the summary row")
    }

    func offers(_ title: String) {
        expectEqual(subject.button, title, "the summary row's button")
    }
}

extension Then where Subject == DigestStatus {
    func showsProcessingWithAStepBar() {
        expect(subject.title?.hasPrefix(Copy.processingTranscript) == true,
               "expected the Transcript tab to say \"\(Copy.processingTranscript)\", found \(String(describing: subject.title))")
        expect(subject.hasSteps, "expected a step bar under \"\(Copy.processingTranscript)\"")
    }

    func showsFailure(_ text: String) {
        expect(subject.failure?.hasPrefix(text) == true,
               "expected the Transcript tab to say \"\(text)\", found \(String(describing: subject.failure))")
    }

    func offersRetry() {
        expect(subject.offersRetry, "expected a Retry button under the failure")
    }
}

extension Then where Subject == AlertReadout {
    func showsAnAlertThatTranscriptionIsPaused() {
        let shown = subject.titles.contains {
            $0.localizedCaseInsensitiveContains("transcription") && $0.localizedCaseInsensitiveContains("paused")
        }
        expect(shown, "no info alert says transcription is paused with work pending; alerts shown: \(subject.titles)")
    }
}

// MARK: - Given

extension Given {
    /// Jane Doe's summaries, with the background scheduler attached.
    func summaries(model: SteeredModel = SteeredModel()) async throws -> SummariesDesk {
        let desk = assistantDesk(model: model)
        let jane = try await patient(named: "Jane Doe")
        return SummariesDesk(desk: desk, patient: jane)
    }
}
