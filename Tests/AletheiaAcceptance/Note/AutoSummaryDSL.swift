@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// What came of a session once it was recorded and transcribed.
struct AutoSummaryResult {
    /// The summary saved for the session, nil when none was written.
    let note: String?
    let isUnsignedDraft: Bool
    let isUntouchedAIText: Bool
    /// Every notification, as "title: body".
    let notifications: [String]
    /// How many times the AI was asked anything.
    let modelRequests: Int
    /// Whether a summary is still waiting to be written.
    let isWaitingToBeWritten: Bool
}

/// A speech model that always hears the same short session.
private final class ShortSessionTranscriber: Transcribing, @unchecked Sendable {
    var isReady: Bool { true }
    func transcribeSession(
        micURL: URL?, callURL: URL?, onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        TranscriptFormatter.format([
            TranscribedLine(source: "You", startTime: 0, endTime: 3, text: "How has your week been?"),
            TranscribedLine(source: "Client", startTime: 4, endTime: 9, text: "Better. I slept most nights and walked twice."),
        ])
    }
}

// MARK: - The desk

/// Recording a session and letting it transcribe, over the real coordinator,
/// scheduler and note, with the speech model and the AI swapped for ones the
/// test controls. The scheduler is attached the way the app attaches it.
@MainActor
final class AutoSummaryDesk {
    let desk: AssistantDesk
    let patient: Patient
    private let coordinator: TranscriptionCoordinator
    private static let rawAudio = Data("RAW-AUDIO-MARKER".utf8)

    fileprivate init(desk: AssistantDesk, patient: Patient) {
        self.desk = desk
        self.patient = patient
        let app = desk.app
        coordinator = TranscriptionCoordinator(
            appModel: app.appModel, integrations: desk.integrations, settings: app.settings, now: { app.clock.now })
        desk.model.fallback("Client reports a better week: sleeping most nights and walking twice.")
        startScheduler()
    }

    private var scheduler: DigestScheduler { desk.integrations.digestScheduler }

    private func startScheduler() {
        let scheduler = scheduler
        let app = desk.app
        scheduler.drafter = AutoNoteDrafter(appModel: app.appModel, integrations: desk.integrations, settings: app.settings)
        app.stopOnShutDown { await scheduler.shutDown() }
        scheduler.attach(
            context: { [weak self] in
                guard let self, let store = try? self.desk.store else { return nil }
                return DigestScheduler.Context(
                    store: store, patients: self.desk.app.appModel.patients,
                    service: self.desk.integrations.makeAssistantService())
            },
            activity: { [weak self] in
                DigestActivity(transcribing: self?.coordinator.isBusy ?? false)
            })
    }

    // MARK: Scene

    /// Turns "Write the summary after recording" on or off in General.
    func summarizeAfterRecording(_ on: Bool) { desk.settings.summarizesAfterRecording = on }

    /// Presses Pause on the summaries.
    func pauseSummaries() { desk.settings.summariesPaused = true }

    /// Presses Resume on the summaries.
    func resumeSummaries() { scheduler.perform(.resume, patientID: patient.id) }

    // MARK: Actions

    /// Records a session and lets it transcribe to the end.
    func recordAndTranscribe() async throws -> StoredSession {
        let store = try desk.store
        let created = try store.createSession(for: patient, on: desk.app.clock.now)
        try Self.rawAudio.write(to: store.micRecordingURL(for: patient, session: created))
        try Self.rawAudio.write(to: store.callRecordingURL(for: patient, session: created))
        desk.app.appModel.refreshPatients()
        coordinator.start(patient: patient, session: created)
        try await eventually("the transcription to end") { self.coordinator.outcomes[created.id] != nil }
        let outcome = coordinator.takeOutcome(for: created.id)
        guard case .completed? = outcome else {
            XCTFail("the transcription did not complete: \(String(describing: outcome))")
            return StoredSession(patient: patient, session: created)
        }
        return StoredSession(patient: patient, session: created)
    }

    /// Waits until the session's summary is saved and "Summary ready" has arrived.
    func waitForTheSummary(of stored: StoredSession) async throws {
        try await desk.waitFor("the summary to be written", within: 20, describe: {
            "notes wanted \(self.scheduler.notesWanted), pause \(String(describing: self.scheduler.pauseReason)); "
                + "model asked \(self.desk.model.startedCount)"
        }) {
            self.savedNote(of: stored) != nil && self.desk.notifier.titles.contains(Copy.summaryReadyTitle)
        }
    }

    /// Waits until the scheduler has taken the request in and holds it while summaries are paused.
    func waitUntilTheSummaryIsHeld() async throws {
        try await desk.waitFor("the summary to be held while paused", describe: {
            "notes wanted \(self.scheduler.notesWanted), pause \(String(describing: self.scheduler.pauseReason))"
        }) {
            self.scheduler.notesWanted == 1 && self.scheduler.pauseReason == .user
        }
    }

    /// Lets the background work look again, as its next check would.
    func letTheBackgroundWorkLookAgain() async {
        scheduler.evaluate()
        await Task { @MainActor in }.value
        scheduler.evaluate()
    }

    // MARK: Reading

    private func savedNote(of stored: StoredSession) -> String? {
        guard let store = try? desk.store else { return nil }
        let text = store.note(for: stored.patient, session: stored.session, format: desk.settings.progressNoteFormat) ?? ""
        return text.isEmpty ? nil : text
    }

    func result(for stored: StoredSession) throws -> AutoSummaryResult {
        let store = try desk.store
        let format = desk.settings.progressNoteFormat
        let lifecycle = try store.noteLifecycle(for: stored.patient, session: stored.session, format: format)
        return AutoSummaryResult(
            note: savedNote(of: stored),
            isUnsignedDraft: lifecycle == .draft,
            isUntouchedAIText: store.noteEditState(for: stored.patient, session: stored.session, format: format) == .generated,
            notifications: desk.notifier.shown,
            modelRequests: desk.model.startedCount,
            isWaitingToBeWritten: scheduler.notesWanted > 0)
    }
}

// MARK: - Given

extension Given {
    /// Jane Doe, about to be recorded, with the background work running.
    func autoSummaries(model: SteeredModel = SteeredModel()) async throws -> AutoSummaryDesk {
        let desk = assistantDesk(model: model, transcriber: ShortSessionTranscriber())
        let jane = try await patient(named: "Jane Doe")
        return AutoSummaryDesk(desk: desk, patient: jane)
    }
}

// MARK: - Then

extension Then where Subject == AutoSummaryResult {
    func hasAnUnsignedAIDraft() {
        expect(subject.note != nil, "a summary should have been written")
        expect(subject.isUnsignedDraft, "the summary should be an unsigned draft")
        expect(subject.isUntouchedAIText, "the summary should be the AI's text, as written")
    }

    func hasNoSummary() {
        expect(subject.note == nil, "no summary should be written, found: \(subject.note ?? "")")
        expectEqual(subject.modelRequests, 0, "how many times the AI was asked")
    }

    func announcedTheSummaryWithoutTheName(_ name: String) {
        let ready = subject.notifications.filter { $0.hasPrefix(Copy.summaryReadyTitle + ":") }
        expectEqual(ready.count, 1, "\"\(Copy.summaryReadyTitle)\" notifications, of \(subject.notifications)")
        let initials = name.split(separator: " ").compactMap(\.first).map(String.init)
        for shown in ready {
            for part in name.split(separator: " ") {
                expect(!shown.contains(part), "the notification should not name the patient: \(shown)")
            }
            expect(!shown.contains(initials.joined()) && !shown.contains(initials.joined(separator: ".") + "."),
                   "the notification should not show the patient's initials: \(shown)")
        }
    }

    func isNotWaitingToBeWritten() {
        expect(!subject.isWaitingToBeWritten, "no summary should be waiting to be written")
    }

    func announcedNoSummary() {
        expect(!subject.notifications.contains { $0.hasPrefix(Copy.summaryReadyTitle + ":") },
               "no \"\(Copy.summaryReadyTitle)\" notification expected, got \(subject.notifications)")
    }
}
